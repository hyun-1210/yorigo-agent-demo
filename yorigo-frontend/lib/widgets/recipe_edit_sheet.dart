import 'package:flutter/material.dart';
import 'app_toast.dart';
import 'package:flutter/services.dart';
import '../utils/ingredient_category_unifier.dart';
import 'ingredient_seed_picker.dart';

/// 레시피 디테일에서 사용자 로컬 오버레이를 편집하는 바텀시트.
///
/// 모드별 노출 필드:
///   - [RecipeEditSheetMode.recipeMemo]            : 메모만
///   - [RecipeEditSheetMode.ingredientEditOriginal] : qty / unit / 메모 (재료명 read-only)
///   - [RecipeEditSheetMode.ingredientEditAdded]    : item / qty / unit / 카테고리 / 메모
///   - [RecipeEditSheetMode.ingredientAdd]          : 시드 picker → item / qty / unit / 카테고리 / 메모
///   - [RecipeEditSheetMode.stepEditOriginal]       : instruction / 메모 (원본 스텝)
///   - [RecipeEditSheetMode.stepEditAdded]          : instruction / 메모 / 위치
///   - [RecipeEditSheetMode.stepAdd]                : instruction / 메모 / 위치
///
/// 콜백:
///   - [onSave]    : 저장. 새 값들을 [RecipeEditSheetResult] 로 받아 호출자가 저장 처리.
///   - [onDelete]  : 항목 삭제(원본은 removed 표시, added 는 완전 제거).
enum RecipeEditSheetMode {
  recipeMemo,
  ingredientEditOriginal,
  ingredientEditAdded,
  ingredientAdd,
  stepEditOriginal,
  stepEditAdded,
  stepAdd,
}

/// 스텝 위치 dropdown 의 한 옵션. 디스플레이 라벨은 "맨 처음 / N번 뒤: <앞 30자> / 맨 끝".
class StepAnchorOption {
  StepAnchorOption({required this.label, required this.anchor});
  final String label;
  final Map<String, dynamic> anchor;
}

class RecipeEditSheetResult {
  RecipeEditSheetResult({
    this.item,
    this.qty,
    this.unit,
    this.categoryKey,
    this.instruction,
    this.memo,
    this.anchor,
  });

  final String? item;
  final double? qty;
  final String? unit;
  final String? categoryKey;
  final String? instruction;
  final String? memo;
  final Map<String, dynamic>? anchor;
}

/// 모달 시트 노출 헬퍼. 부모는 [onSave] 안에서 [LocalStorageService] 호출 후 setState.
Future<void> showRecipeEditSheet(
  BuildContext context, {
  required RecipeEditSheetMode mode,
  required Future<void> Function(RecipeEditSheetResult result) onSave,
  Future<void> Function()? onDelete,
  String? initialItem,
  double? initialQty,
  String? initialUnit,
  String? initialCategoryKey,
  String? initialInstruction,
  String? initialMemo,
  Map<String, dynamic>? initialAnchor,
  List<StepAnchorOption>? anchorOptions,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecipeEditSheet(
      mode: mode,
      onSave: onSave,
      onDelete: onDelete,
      initialItem: initialItem,
      initialQty: initialQty,
      initialUnit: initialUnit,
      initialCategoryKey: initialCategoryKey,
      initialInstruction: initialInstruction,
      initialMemo: initialMemo,
      initialAnchor: initialAnchor,
      anchorOptions: anchorOptions,
    ),
  );
}

class _RecipeEditSheet extends StatefulWidget {
  const _RecipeEditSheet({
    required this.mode,
    required this.onSave,
    this.onDelete,
    this.initialItem,
    this.initialQty,
    this.initialUnit,
    this.initialCategoryKey,
    this.initialInstruction,
    this.initialMemo,
    this.initialAnchor,
    this.anchorOptions,
  });

  final RecipeEditSheetMode mode;
  final Future<void> Function(RecipeEditSheetResult result) onSave;
  final Future<void> Function()? onDelete;
  final String? initialItem;
  final double? initialQty;
  final String? initialUnit;
  final String? initialCategoryKey;
  final String? initialInstruction;
  final String? initialMemo;
  final Map<String, dynamic>? initialAnchor;
  final List<StepAnchorOption>? anchorOptions;

  @override
  State<_RecipeEditSheet> createState() => _RecipeEditSheetState();
}

class _RecipeEditSheetState extends State<_RecipeEditSheet> {
  late final TextEditingController _itemController;
  late final TextEditingController _qtyController;
  late final TextEditingController _unitController;
  late final TextEditingController _instructionController;
  late final TextEditingController _memoController;
  String _categoryKey = IngredientCategoryUnifier.vegFruit;

  /// stepAdd / stepEditAdded 모드에서 사용. 선택된 anchor option index.
  int _anchorIndex = 0;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _itemController = TextEditingController(text: widget.initialItem ?? '');
    _qtyController = TextEditingController(
      text: widget.initialQty != null
          ? _formatQty(widget.initialQty!)
          : '',
    );
    _unitController = TextEditingController(text: widget.initialUnit ?? '');
    _instructionController =
        TextEditingController(text: widget.initialInstruction ?? '');
    _memoController = TextEditingController(text: widget.initialMemo ?? '');
    _categoryKey =
        widget.initialCategoryKey ?? IngredientCategoryUnifier.vegFruit;

    final options = widget.anchorOptions;
    if (options != null && widget.initialAnchor != null) {
      final initial = widget.initialAnchor!;
      _anchorIndex = options.indexWhere(
        (opt) => _anchorEquals(opt.anchor, initial),
      );
      if (_anchorIndex < 0) _anchorIndex = options.length - 1; // 기본: 맨 끝
    } else if (options != null) {
      _anchorIndex = options.length - 1; // 기본: 맨 끝
    }
  }

  @override
  void dispose() {
    _itemController.dispose();
    _qtyController.dispose();
    _unitController.dispose();
    _instructionController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  bool _anchorEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    return a['type'] == b['type'] && a['value'] == b['value'];
  }

  String _formatQty(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toString();
  }

  String get _title {
    switch (widget.mode) {
      case RecipeEditSheetMode.recipeMemo:
        return '내 메모';
      case RecipeEditSheetMode.ingredientEditOriginal:
      case RecipeEditSheetMode.ingredientEditAdded:
        return '재료 편집';
      case RecipeEditSheetMode.ingredientAdd:
        return '재료 추가';
      case RecipeEditSheetMode.stepEditOriginal:
      case RecipeEditSheetMode.stepEditAdded:
        return '단계 편집';
      case RecipeEditSheetMode.stepAdd:
        return '단계 추가';
    }
  }

  String get _saveLabel {
    switch (widget.mode) {
      case RecipeEditSheetMode.ingredientAdd:
      case RecipeEditSheetMode.stepAdd:
        return '추가';
      default:
        return '저장';
    }
  }

  bool get _showItemField =>
      widget.mode == RecipeEditSheetMode.ingredientEditAdded ||
      widget.mode == RecipeEditSheetMode.ingredientAdd;

  bool get _showItemReadOnly =>
      widget.mode == RecipeEditSheetMode.ingredientEditOriginal;

  bool get _showQtyUnitFields =>
      widget.mode == RecipeEditSheetMode.ingredientEditOriginal ||
      widget.mode == RecipeEditSheetMode.ingredientEditAdded ||
      widget.mode == RecipeEditSheetMode.ingredientAdd;

  bool get _showCategoryField =>
      widget.mode == RecipeEditSheetMode.ingredientEditAdded ||
      widget.mode == RecipeEditSheetMode.ingredientAdd;

  bool get _showInstructionField =>
      widget.mode == RecipeEditSheetMode.stepEditOriginal ||
      widget.mode == RecipeEditSheetMode.stepEditAdded ||
      widget.mode == RecipeEditSheetMode.stepAdd;

  bool get _showAnchorField =>
      (widget.mode == RecipeEditSheetMode.stepAdd ||
              widget.mode == RecipeEditSheetMode.stepEditAdded) &&
          widget.anchorOptions != null &&
          widget.anchorOptions!.isNotEmpty;

  bool get _showSeedPicker =>
      widget.mode == RecipeEditSheetMode.ingredientAdd;

  Future<void> _handleSave() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final result = RecipeEditSheetResult(
        item: _showItemField ? _itemController.text.trim() : widget.initialItem,
        qty: _showQtyUnitFields ? double.tryParse(_qtyController.text.trim()) : null,
        unit: _showQtyUnitFields ? _unitController.text.trim() : null,
        categoryKey: _showCategoryField ? _categoryKey : null,
        instruction:
            _showInstructionField ? _instructionController.text.trim() : null,
        memo: _memoController.text.trim(),
        anchor: _showAnchorField
            ? widget.anchorOptions![_anchorIndex].anchor
            : null,
      );
      await widget.onSave(result);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('저장 실패: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _handleDelete() async {
    final del = widget.onDelete;
    if (del == null || _saving) return;
    setState(() => _saving = true);
    try {
      await del();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('삭제 실패: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E8EB),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    if (_showSeedPicker) ...[
                      IngredientSeedPicker(
                        controller: _itemController,
                        onSelected: (selection) {
                          setState(() {
                            _categoryKey = selection.categoryKey;
                            if (_unitController.text.trim().isEmpty) {
                              _unitController.text = selection.defaultUnit;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_showItemReadOnly) ...[
                      _buildReadOnlyRow('재료명', widget.initialItem ?? ''),
                      const SizedBox(height: 16),
                    ],
                    if (_showItemField && !_showSeedPicker) ...[
                      _buildLabel('재료명'),
                      const SizedBox(height: 6),
                      _buildTextField(
                        controller: _itemController,
                        hintText: '재료명',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_showQtyUnitFields) ...[
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('수량'),
                                const SizedBox(height: 6),
                                _buildTextField(
                                  controller: _qtyController,
                                  hintText: '0',
                                  keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  inputFormatters: <TextInputFormatter>[
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'[0-9.]'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('단위'),
                                const SizedBox(height: 6),
                                _buildTextField(
                                  controller: _unitController,
                                  hintText: '개',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_showCategoryField) ...[
                      _buildLabel('카테고리'),
                      const SizedBox(height: 6),
                      _buildCategoryDropdown(),
                      const SizedBox(height: 16),
                    ],
                    if (_showInstructionField) ...[
                      _buildLabel('설명'),
                      const SizedBox(height: 6),
                      _buildTextField(
                        controller: _instructionController,
                        hintText: '단계 설명',
                        maxLines: 4,
                        minLines: 2,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_showAnchorField) ...[
                      _buildLabel('위치'),
                      const SizedBox(height: 6),
                      _buildAnchorDropdown(),
                      const SizedBox(height: 16),
                    ],
                    _buildLabel(
                      widget.mode == RecipeEditSheetMode.recipeMemo
                          ? '메모'
                          : '메모 (선택)',
                    ),
                    const SizedBox(height: 6),
                    _buildTextField(
                      controller: _memoController,
                      hintText: widget.mode == RecipeEditSheetMode.recipeMemo
                          ? '레시피 전체에 남길 메모를 적어주세요'
                          : '직접 적용한 변경사항 등 자유 메모',
                      maxLines: 4,
                      minLines: 2,
                    ),
                    const SizedBox(height: 24),
                    _buildButtonRow(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            _title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
              color: Color(0xFF191F28),
            ),
          ),
        ),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: Color(0xFF8B95A1),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF6B7280),
          letterSpacing: -0.3,
        ),
      );

  Widget _buildReadOnlyRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0F2F5), width: 1),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8B95A1),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF191F28),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    String? hintText,
    int? minLines,
    int? maxLines = 1,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
        minLines: minLines,
        maxLines: maxLines,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Color(0xFF191F28),
        ),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: Color(0xFFB0B8C1),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    final keys = IngredientCategoryUnifier.groupOrder;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<String>(
        value: keys.contains(_categoryKey) ? _categoryKey : keys.first,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.keyboard_arrow_down_rounded,
            color: Color(0xFF8B95A1)),
        items: keys
            .map(
              (k) => DropdownMenuItem<String>(
                value: k,
                child: Row(
                  children: [
                    IngredientCategoryUnifier.buildCategoryIcon(
                        key: k, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      IngredientCategoryUnifier.titleFromKey(k),
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF191F28),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(growable: false),
        onChanged: (v) {
          if (v != null) setState(() => _categoryKey = v);
        },
      ),
    );
  }

  Widget _buildAnchorDropdown() {
    final options = widget.anchorOptions!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<int>(
        value: _anchorIndex.clamp(0, options.length - 1),
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.keyboard_arrow_down_rounded,
            color: Color(0xFF8B95A1)),
        items: List<DropdownMenuItem<int>>.generate(
          options.length,
          (i) => DropdownMenuItem<int>(
            value: i,
            child: Text(
              options[i].label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF191F28),
              ),
            ),
          ),
        ),
        onChanged: (v) {
          if (v != null) setState(() => _anchorIndex = v);
        },
      ),
    );
  }

  Widget _buildButtonRow() {
    final hasDelete = widget.onDelete != null;
    final saveButton = Expanded(
      flex: 3,
      child: SizedBox(
        height: 50,
        child: ElevatedButton(
          onPressed: _saving ? null : _handleSave,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF6B00),
            disabledBackgroundColor: const Color(0xFFFFB07A),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Text(
            _saveLabel,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ),
    );

    if (!hasDelete) return Row(children: [saveButton]);

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 50,
            child: OutlinedButton(
              onPressed: _saving ? null : _handleDelete,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFE5E8EB), width: 1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                '삭제',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE94D4D),
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        saveButton,
      ],
    );
  }
}
