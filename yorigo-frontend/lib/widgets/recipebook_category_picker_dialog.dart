import 'package:flutter/material.dart';

/// Result returned by [showRecipebookCategoryMultiPickerDialog].
/// `null` = 사용자가 취소(바깥 영역 탭/뒤로가기). `createRequested == true`
/// 면 caller가 새 카테고리 생성 다이얼로그를 띄운 뒤 picker 를 다시 열어야
/// 한다. 그 외엔 `selectedIds` 가 최종 선택된 카테고리 ID 리스트.
class RecipebookCategoryMultiPickerResult {
  const RecipebookCategoryMultiPickerResult.done(List<String> ids)
    : selectedIds = ids,
      createRequested = false;
  const RecipebookCategoryMultiPickerResult.create()
    : selectedIds = const [],
      createRequested = true;

  final List<String> selectedIds;
  final bool createRequested;
}

/// 다중 선택 picker. 한 레시피에 여러 카테고리를 동시에 지정할 때 사용.
/// 체크박스로 토글하고 "완료" 버튼으로 확정한다. "새 카테고리 만들기"
/// 를 탭하면 [RecipebookCategoryMultiPickerResult.create] 를 반환하므로
/// caller 가 생성 플로우를 처리한 뒤 다시 picker 를 열면 된다.
Future<RecipebookCategoryMultiPickerResult?>
showRecipebookCategoryMultiPickerDialog(
  BuildContext context, {
  required List<Map<String, dynamic>> categories,
  required List<String> initialSelectedIds,
  String title = '카테고리 선택',
  String subtitle = '여러 카테고리를 선택할 수 있어요',
  String createCtaLabel = '새 카테고리 만들기',
  String confirmCtaLabel = '완료',
}) {
  return showDialog<RecipebookCategoryMultiPickerResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) {
      return _RecipebookCategoryMultiPickerDialog(
        categories: categories,
        initialSelectedIds: initialSelectedIds,
        title: title,
        subtitle: subtitle,
        createCtaLabel: createCtaLabel,
        confirmCtaLabel: confirmCtaLabel,
      );
    },
  );
}

/// A single, shared "카테고리 선택" dialog used by both the recipebook tab
/// (home_screen) and the recipe detail screen. Lives here so the two
/// entry points cannot drift visually — exactly the same chrome, list
/// tiles, icons and CTA in both places.
///
/// Special result values returned from [showRecipebookCategoryPickerDialog]:
///   * `__none__`   — user picked the "no category" option
///   * `__create__` — user tapped the bottom "새 카테고리 만들기" CTA
///   * `__manage:<id>` — user long-pressed a non-default category (caller
///                       should open the rename / delete sheet for that id)
///   * any other string — the picked category's id
///
/// Callers handle the return value to either apply a filter, assign a
/// recipe, or fall through to the create dialog.
Future<String?> showRecipebookCategoryPickerDialog(
  BuildContext context, {
  required List<Map<String, dynamic>> categories,
  required String? selectedCategoryId,
  String title = '카테고리 선택',
  String subtitle = '레시피북에서 분류할 카테고리를 선택하세요',
  String noneOptionLabel = '미분류',
  IconData noneOptionIcon = Icons.label_off_rounded,
  String createCtaLabel = '새 카테고리 만들기',
  bool enableLongPressManage = false,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) {
      return RecipebookCategoryPickerDialog(
        categories: categories,
        selectedCategoryId: selectedCategoryId,
        title: title,
        subtitle: subtitle,
        noneOptionLabel: noneOptionLabel,
        noneOptionIcon: noneOptionIcon,
        createCtaLabel: createCtaLabel,
        enableLongPressManage: enableLongPressManage,
      );
    },
  );
}

class RecipebookCategoryPickerDialog extends StatelessWidget {
  const RecipebookCategoryPickerDialog({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    this.title = '카테고리 선택',
    this.subtitle = '레시피북에서 분류할 카테고리를 선택하세요',
    this.noneOptionLabel = '미분류',
    this.noneOptionIcon = Icons.label_off_rounded,
    this.createCtaLabel = '새 카테고리 만들기',
    this.enableLongPressManage = false,
  });

  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final String title;
  final String subtitle;
  final String noneOptionLabel;
  final IconData noneOptionIcon;
  final String createCtaLabel;

  /// When true, long-pressing a non-default category pops the dialog with
  /// `__manage:<id>` so the caller can open its rename / delete sheet.
  final bool enableLongPressManage;

  static const Color _orange = Color(0xFFFF6B00);
  static const Color _ink = Color(0xFF191F28);
  static const Color _inkMuted = Color(0xFF8B95A1);
  static const Color _neutralBorder = Color(0xFFE8EDF3);

  /// Mirrors the icon lookup used by UserService — keeps recipebook
  /// category glyphs identical wherever they're rendered.
  static IconData resolveCategoryIcon(String iconKey) {
    switch (iconKey) {
      case 'none':
        return Icons.layers_clear_rounded;
      case 'rocket':
        return Icons.rocket_launch_rounded;
      case 'heart':
        return Icons.favorite_rounded;
      case 'group':
        return Icons.group_rounded;
      case 'replay':
        return Icons.replay_rounded;
      case 'flame':
        return Icons.local_fire_department_rounded;
      case 'chef':
        return Icons.restaurant_menu_rounded;
      case 'book':
        return Icons.menu_book_rounded;
      case 'star':
        return Icons.star_rounded;
      case 'flag':
        return Icons.flag_rounded;
      case 'check':
        return Icons.task_alt_rounded;
      default:
        return Icons.folder_rounded;
    }
  }

  Widget _buildOptionTile({
    required BuildContext ctx,
    required String categoryId,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    // Monochrome "선택됨" — clarity of white & black is the language here.
    // The tile stays pure white; selection is signalled by (a) a crisp 1.5px
    // ink-dark ring and (b) a bold ink check on the right. No tinted
    // background, no orange splat — feels like Toss / iOS settings list.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: EdgeInsets.symmetric(
              // Compensate for the 0.5px thicker selected border so the
              // tile's inner content doesn't shift horizontally on tap.
              horizontal: selected ? 11.5 : 12,
              vertical: selected ? 11.5 : 12,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? _ink : _neutralBorder,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? _ink : _inkMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: _ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: _ink,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxDialogHeight = MediaQuery.of(context).size.height * 0.72;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxDialogHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 18, 0, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                // Pulls the header flush to the left edge of the dialog
                // (less indented than the option tiles below), so the
                // section title reads as the modal's heading instead of a
                // sibling card. Right padding kept generous so long titles
                // wrap nicely.
                padding: const EdgeInsets.fromLTRB(6, 0, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: _inkMuted,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildOptionTile(
                        ctx: context,
                        categoryId: '__none__',
                        icon: noneOptionIcon,
                        label: noneOptionLabel,
                        selected: selectedCategoryId == null,
                        onTap: () => Navigator.pop(context, '__none__'),
                      ),
                      ...categories.map((category) {
                        final id = (category['id'] as String?) ?? '';
                        final name = (category['name'] as String?) ?? '';
                        if (id.isEmpty || name.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        final iconKey =
                            ((category['iconKey'] as String?) ?? '')
                                .trim()
                                .isNotEmpty
                            ? (category['iconKey'] as String).trim()
                            : 'folder';
                        final isDefault = category['isDefault'] == true;
                        return _buildOptionTile(
                          ctx: context,
                          categoryId: id,
                          icon: resolveCategoryIcon(iconKey),
                          label: name,
                          selected: id == selectedCategoryId,
                          onTap: () => Navigator.pop(context, id),
                          onLongPress: (enableLongPressManage && !isDefault)
                              ? () => Navigator.pop(context, '__manage:$id')
                              : null,
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => Navigator.pop(context, '__create__'),
                    borderRadius: BorderRadius.circular(14),
                    child: Ink(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _neutralBorder),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.add_circle_outline_rounded,
                            size: 18,
                            color: _orange,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              createCtaLabel,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _orange,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
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

// ─── Multi-select picker (체크박스 + 완료) ─────────────────────────────
//
// 단일 선택 picker 와 시각적 통일성을 위해 같은 색/타일/CTA 디자인을
// 재사용한다. 차이점:
//   • 옵션 타일을 탭하면 토글(추가/해제), 다이얼로그가 닫히지 않음
//   • 오른쪽 표시가 체크박스로 바뀌고 다중 선택을 허용
//   • 하단에 "새 카테고리 만들기"(보조) + "완료"(주) 두 버튼
//   • 결과는 List<String> 으로 반환 (빈 리스트 = 미분류)
class _RecipebookCategoryMultiPickerDialog extends StatefulWidget {
  const _RecipebookCategoryMultiPickerDialog({
    required this.categories,
    required this.initialSelectedIds,
    required this.title,
    required this.subtitle,
    required this.createCtaLabel,
    required this.confirmCtaLabel,
  });

  final List<Map<String, dynamic>> categories;
  final List<String> initialSelectedIds;
  final String title;
  final String subtitle;
  final String createCtaLabel;
  final String confirmCtaLabel;

  @override
  State<_RecipebookCategoryMultiPickerDialog> createState() =>
      _RecipebookCategoryMultiPickerDialogState();
}

class _RecipebookCategoryMultiPickerDialogState
    extends State<_RecipebookCategoryMultiPickerDialog> {
  static const Color _orange = Color(0xFFFF6B00);
  static const Color _ink = Color(0xFF191F28);
  static const Color _inkMuted = Color(0xFF8B95A1);
  static const Color _neutralBorder = Color(0xFFE8EDF3);

  late final Set<String> _selected = {...widget.initialSelectedIds};

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  Widget _buildCheckTile({
    required String id,
    required IconData icon,
    required String label,
    required bool selected,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _toggle(id),
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            padding: EdgeInsets.symmetric(
              horizontal: selected ? 11.5 : 12,
              vertical: selected ? 11.5 : 12,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? _ink : _neutralBorder,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: selected ? _ink : _inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: selected
                          ? FontWeight.w800
                          : FontWeight.w600,
                      color: _ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                // 체크박스: 선택 시 ink-fill + 흰색 체크, 미선택 시 빈 라운드 박스
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: selected ? _ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected ? _ink : _neutralBorder,
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Colors.white,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxDialogHeight = MediaQuery.of(context).size.height * 0.72;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxDialogHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 18, 0, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: _inkMuted,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...widget.categories.map((category) {
                        final id = (category['id'] as String?) ?? '';
                        final name = (category['name'] as String?) ?? '';
                        if (id.isEmpty || name.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        final iconKey =
                            ((category['iconKey'] as String?) ?? '')
                                .trim()
                                .isNotEmpty
                            ? (category['iconKey'] as String).trim()
                            : 'folder';
                        return _buildCheckTile(
                          id: id,
                          icon: RecipebookCategoryPickerDialog
                              .resolveCategoryIcon(iconKey),
                          label: name,
                          selected: _selected.contains(id),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => Navigator.pop(
                            context,
                            const RecipebookCategoryMultiPickerResult.create(),
                          ),
                          borderRadius: BorderRadius.circular(14),
                          child: Ink(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: _neutralBorder),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.add_circle_outline_rounded,
                                  size: 18,
                                  color: _orange,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    widget.createCtaLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: _orange,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => Navigator.pop(
                            context,
                            RecipebookCategoryMultiPickerResult.done(
                              _selected.toList(),
                            ),
                          ),
                          borderRadius: BorderRadius.circular(14),
                          child: Ink(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: _ink,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  widget.confirmCtaLabel,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
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
      ),
    );
  }
}
