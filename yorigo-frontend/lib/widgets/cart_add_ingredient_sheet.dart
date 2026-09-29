import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ingredient_shelf_life_seed.dart';
import '../theme/app_colors.dart';
import '../utils/haptics.dart';
import '../utils/ingredient_category_unifier.dart';
import 'ingredient_seed_picker.dart';

/// 장바구니에 임의 재료를 추가하는 바텀시트.
/// 시드(데이터베이스)에 있는 재료만 검색·선택해서 추가할 수 있다.
Future<CartManualIngredientDraft?> showCartAddIngredientSheet(
  BuildContext context,
) {
  return showModalBottomSheet<CartManualIngredientDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => const _CartAddIngredientSheet(),
  );
}

class CartManualIngredientDraft {
  const CartManualIngredientDraft({
    required this.name,
    required this.qty,
    required this.unit,
    required this.categoryKey,
  });

  final String name;
  final double qty;
  final String unit;
  final String categoryKey;
}

class _CartAddIngredientSheet extends StatefulWidget {
  const _CartAddIngredientSheet();

  @override
  State<_CartAddIngredientSheet> createState() =>
      _CartAddIngredientSheetState();
}

class _CartAddIngredientSheetState extends State<_CartAddIngredientSheet> {
  final _searchController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _searchFocus = FocusNode();
  final _qtyFocus = FocusNode();
  final _scrollController = ScrollController();

  String? _selectedName;
  String _unit = '개';
  String _categoryKey = IngredientCategoryUnifier.vegFruit;

  static const _units = <String>['개', 'g', 'kg', 'ml', 'L', '큰술', '작은술', '모'];

  bool get _hasSeedSelection {
    final name = _searchController.text.trim();
    return name.isNotEmpty &&
        _selectedName == name &&
        ingredientShelfLifeSeedData.containsKey(name);
  }

  bool get _canSubmit {
    final qty =
        double.tryParse(_qtyController.text.trim().replaceAll(',', '')) ?? 0;
    return _hasSeedSelection && qty > 0;
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onFieldsChanged);
    _qtyController.addListener(_onFieldsChanged);
    _qtyFocus.addListener(_onFieldsChanged);
  }

  void _onFieldsChanged() {
    final name = _searchController.text.trim();
    if (_selectedName != null && _selectedName != name) {
      _selectedName = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onFieldsChanged)
      ..dispose();
    _qtyController
      ..removeListener(_onFieldsChanged)
      ..dispose();
    _qtyFocus.removeListener(_onFieldsChanged);
    _searchFocus.dispose();
    _qtyFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSeedSelected(IngredientSeedSelection selection) {
    setState(() {
      _selectedName = selection.name;
      _unit = selection.defaultUnit;
      _categoryKey = selection.categoryKey;
      if (!_units.contains(_unit)) {
        _unit = '개';
      }
    });
    // 재료 고른 뒤 수량으로 포커스 이동 → 키보드 유지 + 다음 입력 유도
    _qtyFocus.requestFocus();
    _qtyController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _qtyController.text.length,
    );
  }

  void _onSearchSubmitted(String value) {
    if (!_hasSeedSelection) {
      Haptics.light();
      _searchFocus.requestFocus();
      return;
    }
    _qtyFocus.requestFocus();
    _qtyController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _qtyController.text.length,
    );
  }

  void _submit() {
    if (!_hasSeedSelection) {
      Haptics.light();
      _searchFocus.requestFocus();
      return;
    }
    final name = _selectedName!;
    final qty =
        double.tryParse(_qtyController.text.trim().replaceAll(',', '')) ?? 0;
    if (qty <= 0) {
      Haptics.light();
      _qtyFocus.requestFocus();
      return;
    }

    FocusScope.of(context).unfocus();
    Haptics.medium();
    Navigator.of(context).pop(
      CartManualIngredientDraft(
        name: name,
        qty: qty,
        unit: _unit,
        categoryKey: _categoryKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom;
    // 키보드가 올라오면 가용 높이가 줄어들므로 maxHeight를 그에 맞게 제한
    final maxHeight = (media.size.height - bottomInset) * 0.92;

    // 투명 시트는 전체 높이를 차지해 기본 barrier 탭이 안 먹을 수 있음 →
    // 어두운 영역 탭 시 직접 pop, 흰 시트 영역은 탭을 흡수.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).maybePop(),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {}, // 시트 본문 탭은 닫기로 전파되지 않게
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 28,
                          offset: const Offset(0, -8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      // 키보드 + 추천 목록이 겹쳐도 전체가 스크롤되도록 한 덩어리로 구성
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                        width: double.infinity,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xFFFFF5ED),
                              Color(0xFFFFFFFF),
                            ],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE0E4EA),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Expanded(
                                    child: Text(
                                      '재료 추가',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 22,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.55,
                                        height: 1.15,
                                        color: Color(0xFF111827),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Material(
                                    color: const Color(0xFFF3F4F6),
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () => Navigator.of(context).pop(),
                                      child: const SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: Color(0xFF6B7280),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                '등록된 재료를 검색해 장보기 목록에 추가해요',
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -0.2,
                                  height: 1.35,
                                  color: Color(0xFF8B95A1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            IngredientSeedPicker(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              onSelected: _onSeedSelected,
                              autofocus: true,
                              textInputAction: TextInputAction.next,
                              onSubmitted: _onSearchSubmitted,
                              hintText: '재료명을 검색하세요',
                            ),
                            if (_hasSeedSelection) ...[
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF4EC),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0xFFFFD8C2),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IngredientCategoryUnifier
                                          .buildCategoryIcon(
                                        key: _categoryKey,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _selectedName!,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF191F28),
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Text(
                                        '선택됨',
                                        style: TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            const Text(
                              '수량',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.15,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: _FieldShell(
                                    focused: _qtyFocus.hasFocus,
                                    child: TextField(
                                      controller: _qtyController,
                                      focusNode: _qtyFocus,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: (_) => _submit(),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'[0-9.]'),
                                        ),
                                      ],
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF191F28),
                                        letterSpacing: -0.3,
                                      ),
                                      cursorColor: AppColors.primary,
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        hintText: '0',
                                        hintStyle: TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFFB0B8C1),
                                        ),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: _FieldShell(
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _units.contains(_unit)
                                            ? _unit
                                            : '개',
                                        isExpanded: true,
                                        borderRadius: BorderRadius.circular(14),
                                        icon: const Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          color: Color(0xFF8B95A1),
                                        ),
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF191F28),
                                          letterSpacing: -0.3,
                                        ),
                                        items: [
                                          for (final u in _units)
                                            DropdownMenuItem(
                                              value: u,
                                              child: Text(u),
                                            ),
                                        ],
                                        onChanged: (v) {
                                          if (v == null) return;
                                          setState(() => _unit = v);
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                          child: SizedBox(
                            height: 54,
                            width: double.infinity,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: _canSubmit
                                    ? [
                                        BoxShadow(
                                          color: AppColors.primary.withValues(
                                            alpha: 0.28,
                                          ),
                                          blurRadius: 16,
                                          offset: const Offset(0, 6),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: ElevatedButton(
                                onPressed: _canSubmit ? _submit : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  disabledBackgroundColor:
                                      const Color(0xFFE5E7EB),
                                  foregroundColor: Colors.white,
                                  disabledForegroundColor:
                                      const Color(0xFF9CA3AF),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Text(
                                  '장보기 목록에 추가',
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldShell extends StatefulWidget {
  const _FieldShell({
    required this.child,
    this.focused = false,
  });

  final Widget child;
  final bool focused;

  @override
  State<_FieldShell> createState() => _FieldShellState();
}

class _FieldShellState extends State<_FieldShell> {
  @override
  Widget build(BuildContext context) {
    final focused = widget.focused;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6F8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: focused ? const Color(0xFFFFD8C2) : const Color(0xFFE8ECF0),
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: const Color(0xFFFF6B2C).withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: widget.child,
    );
  }
}
