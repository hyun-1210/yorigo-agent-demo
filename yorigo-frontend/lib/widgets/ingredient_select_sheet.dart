import 'package:flutter/material.dart';
import '../models/recipe_models.dart' as models;
import '../theme/app_colors.dart';
import '../utils/ingredient_category_unifier.dart';
import 'app_media_query_merge_nav_insets.dart';
import 'step_progress_badge.dart';

const Color _sheetOrange = Color(0xFFFF6B35);
const Color _sheetOrangeLight = Color(0xFFFFF5ED);
const Color _sheetGreen = Color(0xFF5CB030);
const Color _sheetGreenLight = Color(0xFFEEF6C8);

typedef IngredientGroup = ({
  String title,
  String categoryKey,
  List<(int, models.Ingredient)> items,
});

/// Groups a list of ingredients by [IngredientCategoryUnifier] category.
List<IngredientGroup> groupIngredientsByCategory(
    List<models.Ingredient> ingredients) {
  final byGroup = <String, List<(int, models.Ingredient)>>{};
  for (var i = 0; i < ingredients.length; i++) {
    final ing = ingredients[i];
    final groupKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: ing.category,
      ingredientName: ing.item,
    );
    byGroup.putIfAbsent(groupKey, () => <(int, models.Ingredient)>[]);
    byGroup[groupKey]!.add((i, ing));
  }

  final result = <IngredientGroup>[];
  for (final groupKey in IngredientCategoryUnifier.groupOrder) {
    final items = byGroup[groupKey];
    if (items == null || items.isEmpty) continue;
    result.add((
      title: IngredientCategoryUnifier.titleFromKey(groupKey),
      categoryKey: groupKey,
      items: items,
    ));
  }
  return result;
}

/// Shared bottom-sheet for selecting recipe ingredients to add/edit in cart.
///
/// Used by both `RecipeDetailScreen` (add flow) and `CartScreen` (edit flow).
/// Returns `({Set<String> selected, double portionCount})` or `null` if dismissed.
class IngredientSelectSheet extends StatefulWidget {
  final List<models.Ingredient> ingredients;
  final List<IngredientGroup> groups;
  final Set<String> initialSelected;
  final double initialPortionCount;
  final double baseServings;
  final String title;
  final String subtitle;
  final String ctaLabel;
  final bool purchaseCopy;
  final bool isLoading;

  /// Optional step indicator shown above the title (e.g. 1 of 2). Both must be
  /// provided to render it; otherwise the header shows no step UI.
  final int? currentStep;
  final int? totalSteps;

  /// Optional builder for an inline, expandable area shown beneath a row when
  /// its chevron is tapped (e.g. the product browser). When null, rows have no
  /// chevron and behave exactly as before (cart_screen stays unaffected).
  final Widget Function(int index, models.Ingredient ingredient)?
      expansionBuilder;

  const IngredientSelectSheet({
    super.key,
    required this.ingredients,
    required this.groups,
    required this.initialSelected,
    required this.initialPortionCount,
    required this.baseServings,
    this.title = '장바구니에 담기',
    this.subtitle = '집에 없는 재료만 골라 담아보세요',
    this.ctaLabel = '다음',
    this.purchaseCopy = false,
    this.isLoading = false,
    this.currentStep,
    this.totalSteps,
    this.expansionBuilder,
  });

  @override
  State<IngredientSelectSheet> createState() => _IngredientSelectSheetState();
}

class _IngredientSelectSheetState extends State<IngredientSelectSheet> {
  late final Set<String> _selected;
  late double _portionCount;
  final Set<int> _expanded = {};

  static const _metricUnits = {'g', 'kg', 'ml', 'l', 'cc'};
  static const Map<int, Map<int, String>> _fractionGlyphs = {
    2: {1: '½'},
    3: {1: '⅓', 2: '⅔'},
    4: {1: '¼', 3: '¾'},
  };

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
    _portionCount = widget.initialPortionCount;
  }

  double get _portionStep =>
      models.portionStepForBase(widget.baseServings);

  Color get _accent =>
      widget.purchaseCopy ? _sheetGreen : _sheetOrange;
  Color get _accentLight =>
      widget.purchaseCopy ? _sheetGreenLight : _sheetOrangeLight;

  String _toFractionString(double value, {String unit = ''}) {
    final whole = value.truncate();
    final frac = value - whole;

    if (frac.abs() < 1e-9) return whole.toString();

    if (_metricUnits.contains(unit.toLowerCase().trim())) {
      final twoDecimals = value.toStringAsFixed(2);
      if (twoDecimals.endsWith('0')) return value.toStringAsFixed(1);
      return twoDecimals;
    }

    for (final denom in [2, 3, 4]) {
      final numer = (frac * denom).round();
      if ((frac - numer / denom).abs() < 0.01 && numer > 0 && numer < denom) {
        final gcd = numer.gcd(denom);
        final rn = numer ~/ gcd;
        final rd = denom ~/ gcd;
        final glyph = _fractionGlyphs[rd]?[rn];
        if (glyph != null) {
          return whole > 0 ? '$whole$glyph' : glyph;
        }
      }
    }

    final twoDecimals = value.toStringAsFixed(2);
    if (twoDecimals.endsWith('0')) return value.toStringAsFixed(1);
    return twoDecimals;
  }

  String _ingredientQtyText(models.Ingredient ingredient) {
    final cookUnit = (ingredient.unit ?? '').trim();
    final baseQty = ingredient.qty ?? ingredient.qtyConventional;
    final unit = cookUnit.isNotEmpty
        ? cookUnit
        : (ingredient.unitConventional ?? '');
    if (baseQty == null || unit.isEmpty) return '';

    var baseServings = widget.baseServings;
    if (baseServings <= 0) baseServings = 1;
    final scaleFactor = _portionCount / baseServings;
    final scaledAmount = baseQty * scaleFactor;
    final scaled = _toFractionString(scaledAmount, unit: unit);
    if (scaled.isEmpty) return '';
    return '$scaled$unit';
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = AppColors.getTextPrimary(brightness);
    final textTertiary = AppColors.getTextTertiary(brightness);

    return AppMediaQueryMergeNavInsets(
      child: Container(
      height: MediaQuery.of(context).size.height * 0.84,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(20),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE0E2E6),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
            child: Row(
              crossAxisAlignment: widget.subtitle.isEmpty &&
                      widget.currentStep == null
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.currentStep != null &&
                          widget.totalSteps != null) ...[
                        StepProgressBadge(
                          currentStep: widget.currentStep!,
                          totalSteps: widget.totalSteps!,
                        ),
                        const SizedBox(height: 10),
                      ],
                      Text(
                        widget.title,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: textPrimary,
                          letterSpacing: -0.45,
                          height: 1.3,
                        ),
                      ),
                      if (widget.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            color: textTertiary,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.15,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF4F5F7),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Portion selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.purchaseCopy
                        ? '몇 인분으로 구매할까요?'
                        : '몇 인분 만들까요?',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (_portionCount > _portionStep) {
                            setState(() => _portionCount -= _portionStep);
                          }
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF4F5F7),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.remove,
                            size: 16,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        models.formatServingsLabel(_portionCount),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: _accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _portionCount += _portionStep),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF4F5F7),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.add,
                            size: 16,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Ingredient list
          Expanded(
            child: widget.isLoading
                ? Center(
                    child: CircularProgressIndicator(
                      color: _accent,
                      strokeWidth: 2.5,
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    children: [
                      for (var g = 0; g < widget.groups.length; g++) ...[
                        if (g > 0) const SizedBox(height: 10),
                        Builder(
                          builder: (context) {
                            final thisGroup = widget.groups[g];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 2,
                                    bottom: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      IngredientCategoryUnifier
                                          .buildCategoryIcon(
                                        key: thisGroup.categoryKey,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        thisGroup.title,
                                        style: TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: textPrimary,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFEEF0F3),
                                  width: 1,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Column(
                                  children: [
                                    for (
                                      var i = 0;
                                      i < thisGroup.items.length;
                                      i++
                                    ) ...[
                                      Builder(
                                        builder: (context) {
                                          final pair = thisGroup.items[i];
                                          final index = pair.$1;
                                          final ingredient = pair.$2;
                                          final id = index.toString();
                                          final isSelected =
                                              _selected.contains(id);
                                          final qtyStr =
                                              _ingredientQtyText(ingredient);
                                          final hasExpansion =
                                              widget.expansionBuilder != null;
                                          final isExpanded =
                                              _expanded.contains(index);
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                width: double.infinity,
                                                color: isSelected
                                                    ? _accentLight
                                                        .withValues(alpha: 0.55)
                                                    : Colors.white,
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: Material(
                                                        color: Colors
                                                            .transparent,
                                                        child: InkWell(
                                                          onTap: () {
                                                            setState(() {
                                                              if (isSelected) {
                                                                _selected
                                                                    .remove(id);
                                                              } else {
                                                                _selected
                                                                    .add(id);
                                                              }
                                                            });
                                                          },
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 12,
                                                              vertical: 10,
                                                            ),
                                                            child: Row(
                                                              children: [
                                                                Container(
                                                                  width: 20,
                                                                  height: 20,
                                                                  decoration:
                                                                      BoxDecoration(
                                                                    color: isSelected
                                                                        ? _accent
                                                                        : const Color(
                                                                            0xFFF9FAFB,
                                                                          ),
                                                                    shape: BoxShape
                                                                        .circle,
                                                                    border:
                                                                        Border
                                                                            .all(
                                                                      color: isSelected
                                                                          ? _accent
                                                                          : const Color(
                                                                              0xFFD0D0D0,
                                                                            ),
                                                                      width:
                                                                          1.5,
                                                                    ),
                                                                  ),
                                                                  alignment:
                                                                      Alignment
                                                                          .center,
                                                                  child: isSelected
                                                                      ? const Icon(
                                                                          Icons
                                                                              .check,
                                                                          size:
                                                                              12,
                                                                          color:
                                                                              Colors.white,
                                                                        )
                                                                      : null,
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                Expanded(
                                                                  child: Text(
                                                                    ingredient
                                                                        .item,
                                                                    style:
                                                                        TextStyle(
                                                                      fontFamily:
                                                                          'Pretendard',
                                                                      fontSize:
                                                                          14,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                      color:
                                                                          textPrimary,
                                                                    ),
                                                                  ),
                                                                ),
                                                                if (qtyStr
                                                                        .isNotEmpty ||
                                                                    ingredient
                                                                        .estimated)
                                                                  Text(
                                                                    qtyStr.isNotEmpty
                                                                        ? qtyStr
                                                                        : '–',
                                                                    style:
                                                                        TextStyle(
                                                                      fontFamily:
                                                                          'Pretendard',
                                                                      fontSize:
                                                                          13,
                                                                      color:
                                                                          textTertiary,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w500,
                                                                    ),
                                                                  ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    if (hasExpansion)
                                                      GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onTap: () {
                                                          setState(() {
                                                            if (isExpanded) {
                                                              _expanded
                                                                  .remove(index);
                                                            } else {
                                                              _expanded
                                                                  .add(index);
                                                            }
                                                          });
                                                        },
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .fromLTRB(
                                                            4,
                                                            14,
                                                            12,
                                                            14,
                                                          ),
                                                          child: AnimatedRotation(
                                                            turns: isExpanded
                                                                ? 0.5
                                                                : 0,
                                                            duration:
                                                                const Duration(
                                                              milliseconds: 180,
                                                            ),
                                                            child: const Icon(
                                                              Icons
                                                                  .keyboard_arrow_down_rounded,
                                                              size: 22,
                                                              color: Color(
                                                                0xFF9CA3AF,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              if (hasExpansion)
                                                AnimatedSize(
                                                  duration: const Duration(
                                                    milliseconds: 220,
                                                  ),
                                                  curve: Curves.easeOut,
                                                  alignment:
                                                      Alignment.topCenter,
                                                  child: isExpanded
                                                      ? Container(
                                                          width:
                                                              double.infinity,
                                                          color: const Color(
                                                            0xFFFBFBFC,
                                                          ),
                                                          child: widget
                                                              .expansionBuilder!(
                                                            index,
                                                            ingredient,
                                                          ),
                                                        )
                                                      : const SizedBox(
                                                          width:
                                                              double.infinity,
                                                        ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                      if (i < thisGroup.items.length - 1)
                                        Divider(
                                          height: 1,
                                          thickness: 1,
                                          indent: 12 + 20 + 8,
                                          endIndent: 12,
                                          color: const Color(0xFFE8E8E8),
                                        ),
                                    ],
                                  ],
                                ),
                              ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
          ),
          // Footer
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: Color(0xFFF2F4F6), width: 1),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Container(
                          padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                          decoration: BoxDecoration(
                            color: _selected.isEmpty
                                ? const Color(0xFFF4F5F7)
                                : _accentLight,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: _selected.isEmpty
                                      ? const Color(0xFFE8EAED)
                                      : _accent,
                                  shape: BoxShape.circle,
                                ),
                                child: _selected.isEmpty
                                    ? null
                                    : const Icon(
                                        Icons.check,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                _selected.isEmpty
                                    ? (widget.purchaseCopy
                                        ? '필요한 재료만 골라 주세요'
                                        : '재료를 선택해 주세요')
                                    : (widget.purchaseCopy
                                        ? '${_selected.length}개 바로 구매'
                                        : '${_selected.length}개 선택됨'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.15,
                                  color: _selected.isEmpty
                                      ? textTertiary
                                      : textPrimary,
                                ),
                              ),
                              ),
                            ],
                          ),
                        ),
                        ),
                        const SizedBox(width: 8),
                        Builder(
                          builder: (context) {
                            final allSelected =
                                widget.ingredients.isNotEmpty &&
                                _selected.length ==
                                    widget.ingredients.length;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  if (allSelected) {
                                    _selected.clear();
                                  } else {
                                    _selected.clear();
                                    for (
                                      var i = 0;
                                      i < widget.ingredients.length;
                                      i++
                                    ) {
                                      _selected.add(i.toString());
                                    }
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: _accentLight,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  allSelected
                                      ? '전체 해제'
                                      : (widget.purchaseCopy
                                          ? '전부 고르기'
                                          : '전체 선택'),
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                    color: _accent,
                                    letterSpacing: -0.2,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _SheetActionPill(
                      label: _selected.isEmpty
                          ? (widget.purchaseCopy
                              ? '필요한 재료만 골라 주세요'
                              : '재료를 선택해 주세요')
                          : widget.ctaLabel,
                      enabled: _selected.isNotEmpty,
                      green: widget.purchaseCopy,
                      onTap: () {
                        Navigator.of(context).pop((
                          selected: Set<String>.from(_selected),
                          portionCount: _portionCount,
                        ));
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _SheetActionPill extends StatelessWidget {
  const _SheetActionPill({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.green = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool green;

  @override
  Widget build(BuildContext context) {
    final borderColor = green
        ? const Color(0xFFC8E86A)
        : const Color(0xFFFFA058);
    final shadowColor = green
        ? const Color(0xFF5CB030)
        : const Color(0xFFFF5A00);
    final fillColors = green
        ? const [
            Color(0xFF3D9B2E),
            Color(0xFF6BBF3A),
            Color(0xFFB4E04A),
            Color(0xFFE8F7B0),
          ]
        : const [
            Color(0xFFEE5200),
            Color(0xFFFF6B00),
            Color(0xFFFF9A38),
            Color(0xFFFFCFA0),
          ];
    final glazeTail = green
        ? const Color(0xFFDCF5A0)
        : const Color(0xFFFFC890);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled ? 1 : 0.55,
        child: Container(
          width: double.infinity,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: enabled ? borderColor : const Color(0xFFD5D8DE),
              width: 1,
            ),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: enabled
                  ? fillColors
                  : const [
                      Color(0xFFE5E7EB),
                      Color(0xFFEEF0F3),
                    ],
              stops: enabled ? const [0.0, 0.30, 0.66, 1.0] : null,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: shadowColor.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox.expand(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white
                                  .withValues(alpha: enabled ? 0.38 : 0.2),
                              Colors.white.withValues(alpha: 0.04),
                              glazeTail.withValues(alpha: enabled ? 0.2 : 0),
                            ],
                            stops: const [0.0, 0.48, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: enabled
                            ? const Color(0xFF191F28)
                            : const Color(0xFF8B95A1),
                        letterSpacing: -0.3,
                      ),
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
