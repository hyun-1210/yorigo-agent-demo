import 'package:flutter/material.dart';
import '../data/ingredient_shelf_life_seed.dart';
import '../utils/ingredient_category_unifier.dart';

/// 시드 데이터(`ingredientShelfLifeSeedData`) 기반 재료 자동완성 picker.
///
/// 냉장고의 `_AddIngredientSheet` 와 동일한 검색 패턴이지만,
/// 재료 추가 시트(`RecipeEditSheet`)에서 인라인으로 임베드해 사용한다.
///
/// 동작:
/// - 검색어 입력 → `name.contains(q)` 로 시드 키 필터 (최대 20개)
/// - 항목 선택 시 [onSelected] 호출 (이름 + 추정 카테고리 + 기본 단위)
/// - 시드에 없는 재료는 검색창에 그대로 두고 자유 타이핑 허용 → 부모가 결정
class IngredientSeedPicker extends StatefulWidget {
  const IngredientSeedPicker({
    super.key,
    required this.controller,
    required this.onSelected,
    this.autofocus = true,
    this.focusNode,
    this.textInputAction = TextInputAction.search,
    this.onSubmitted,
    this.hintText = '재료명을 검색하거나 직접 입력하세요',
  });

  final TextEditingController controller;
  final void Function(IngredientSeedSelection selection) onSelected;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final String hintText;

  @override
  State<IngredientSeedPicker> createState() => _IngredientSeedPickerState();
}

class IngredientSeedSelection {
  IngredientSeedSelection({
    required this.name,
    required this.categoryKey,
    required this.defaultUnit,
  });

  final String name;
  final String categoryKey;
  final String defaultUnit;
}

class _IngredientSeedPickerState extends State<IngredientSeedPicker> {
  static final List<String> _allIngredients =
      ingredientShelfLifeSeedData.keys.toList()..sort();

  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSearchChanged);
    widget.focusNode?.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant IngredientSeedPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChanged);
      widget.focusNode?.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSearchChanged);
    widget.focusNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onSearchChanged() {
    final q = widget.controller.text.trim();
    if (q.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    setState(() {
      _suggestions = _allIngredients
          .where((n) => n.contains(q))
          .take(20)
          .toList(growable: false);
    });
  }

  /// 카테고리 + 이름 휴리스틱으로 기본 단위 추정. fridge_screen 의 동일 함수와 일치.
  static String _defaultUnitForIngredient(String name) {
    final catKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: null,
      ingredientName: name,
    );
    switch (catKey) {
      case IngredientCategoryUnifier.meatProcessedEgg:
      case IngredientCategoryUnifier.seafood:
      case IngredientCategoryUnifier.grains:
        return 'g';
      case IngredientCategoryUnifier.dairy:
        if (name.contains('우유') ||
            name.contains('크림') ||
            name.contains('요거트')) {
          return 'ml';
        }
        return '개';
      case IngredientCategoryUnifier.seasoningsSauces:
        if (name.contains('소스') ||
            name.contains('식초') ||
            name.contains('기름') ||
            name.contains('오일') ||
            name.contains('참기름') ||
            name.contains('들기름') ||
            name.contains('간장') ||
            name.contains('액젓') ||
            name.contains('맛술') ||
            name.contains('술') ||
            name.contains('미림') ||
            name.contains('물엿') ||
            name.contains('시럽') ||
            name.contains('주스')) {
          return 'ml';
        }
        return 'g';
      case IngredientCategoryUnifier.vegFruit:
        if (name.contains('두부')) return '모';
        return '개';
      default:
        return '개';
    }
  }

  void _handleSelect(String name) {
    final categoryKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: null,
      ingredientName: name,
    );
    final unit = _defaultUnitForIngredient(name);
    widget.controller.text = name;
    widget.controller.selection = TextSelection.collapsed(offset: name.length);
    setState(() => _suggestions = const []);
    widget.onSelected(IngredientSeedSelection(
      name: name,
      categoryKey: categoryKey,
      defaultUnit: unit,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: const Color(0xFFF4F6F8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: (widget.focusNode?.hasFocus ?? false)
                  ? const Color(0xFFFFD8C2)
                  : const Color(0xFFE8ECF0),
            ),
            boxShadow: (widget.focusNode?.hasFocus ?? false)
                ? [
                    BoxShadow(
                      color: const Color(0xFFFF6B2C).withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            textInputAction: widget.textInputAction,
            onSubmitted: widget.onSubmitted,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
              color: Color(0xFF191F28),
            ),
            cursorColor: const Color(0xFFFF6B2C),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 15,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
                color: Color(0xFFB0B8C1),
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 14, right: 8),
                child: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: Color(0xFF8B95A1),
                ),
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 42,
                minHeight: 20,
              ),
              suffixIcon: widget.controller.text.isNotEmpty
                  ? GestureDetector(
                      onTap: () {
                        widget.controller.clear();
                        setState(() => _suggestions = const []);
                      },
                      child: const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.cancel_rounded,
                          size: 18,
                          color: Color(0xFFB0B8C1),
                        ),
                      ),
                    )
                  : null,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 30,
                minHeight: 18,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE8ECF0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _suggestions.length,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  indent: 44,
                  color: Color(0xFFF0F2F5),
                ),
                itemBuilder: (context, i) {
                  final name = _suggestions[i];
                  final catKey =
                      IngredientCategoryUnifier.groupKeyFromIngredient(
                    internalCategory: null,
                    ingredientName: name,
                  );
                  final catLabel = IngredientCategoryUnifier.titleFromKey(
                    catKey,
                  );
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _handleSelect(name),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            IngredientCategoryUnifier.buildCategoryIcon(
                              key: catKey,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: Color(0xFF191F28),
                                ),
                              ),
                            ),
                            Text(
                              catLabel,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF9AA3AF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}
