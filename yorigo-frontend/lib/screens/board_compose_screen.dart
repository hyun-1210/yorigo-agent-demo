import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';

import '../models/board_post.dart';
import '../services/board_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../widgets/pick_recipe_tag_sheet.dart';

/// Compose / edit screen for a community board post. Visually modelled after
/// 당근 동네생활 글쓰기: minimal app bar, contextual header card, a single
/// borderless writing surface, and a TIP card at the bottom.
class BoardComposeScreen extends StatefulWidget {
  const BoardComposeScreen._({
    required this.mode,
    this.existingPost,
    this.initialCategory,
  });

  /// Open the screen in "new post" mode. [initialCategory] preselects a
  /// category pill (typically the one the user was browsing).
  factory BoardComposeScreen.create({BoardCategory? initialCategory}) {
    return BoardComposeScreen._(
      mode: BoardComposeMode.create,
      initialCategory: initialCategory,
    );
  }

  /// Open the screen in "edit existing post" mode.
  factory BoardComposeScreen.edit(BoardPost post) {
    return BoardComposeScreen._(
      mode: BoardComposeMode.edit,
      existingPost: post,
    );
  }

  final BoardComposeMode mode;
  final BoardPost? existingPost;
  final BoardCategory? initialCategory;

  @override
  State<BoardComposeScreen> createState() => _BoardComposeScreenState();
}

enum BoardComposeMode { create, edit }

class _BoardComposeScreenState extends State<BoardComposeScreen> {
  final _service = BoardService();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _bodyFocus = FocusNode();
  late BoardCategory _category;
  bool _submitting = false;
  String? _taggedRecipeId;
  String? _taggedRecipeTitle;
  String? _taggedRecipeThumb;

  bool get _isEdit => widget.mode == BoardComposeMode.edit;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingPost;
    if (existing != null) {
      _titleController.text = existing.title;
      _bodyController.text = existing.body;
      _category = BoardCategory.fromId(existing.category);
      _taggedRecipeId = existing.recipeId;
      _taggedRecipeTitle = existing.recipeTitle;
      _taggedRecipeThumb = existing.recipeThumbnailUrl;
    } else {
      // The "전체" pseudo-category isn't writable; default to the first
      // writable option when the user was browsing "전체".
      final initial = widget.initialCategory;
      if (initial == null || initial.id == BoardCategory.all.id) {
        _category = BoardCategory.writable.first;
      } else {
        _category = initial;
      }
    }

    _titleController.addListener(() => setState(() {}));
    _bodyController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_submitting &&
      _titleController.text.trim().isNotEmpty &&
      _bodyController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    try {
      if (_isEdit) {
        await _service.updatePost(
          widget.existingPost!.id,
          category: _category.id,
          title: _titleController.text,
          body: _bodyController.text,
          recipeId: _taggedRecipeId,
          recipeTitle: _taggedRecipeTitle,
          recipeThumbnailUrl: _taggedRecipeThumb,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        final newId = await _service.createPost(
          category: _category.id,
          title: _titleController.text,
          body: _bodyController.text,
          recipeId: _taggedRecipeId,
          recipeTitle: _taggedRecipeTitle,
          recipeThumbnailUrl: _taggedRecipeThumb,
        );
        if (!mounted) return;
        Navigator.of(context).pop(newId);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showAppSnackBar(context, 
        SnackBar(
          content: Text('${_isEdit ? '수정' : '등록'} 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<BoardCategory>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  '카테고리 선택',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              for (final c in BoardCategory.writable)
                ListTile(
                  title: Text(
                    c.label,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                      letterSpacing: -0.25,
                    ),
                  ),
                  trailing: c.id == _category.id
                      ? const Icon(
                          Icons.check_rounded,
                          color: Color(0xFFFF7300),
                        )
                      : null,
                  onTap: () => Navigator.pop(context, c),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _category = picked);
    }
  }

  Future<void> _pickRecipe() async {
    final picked = await PickRecipeTagSheet.show(context);
    if (picked == null || !mounted) return;
    setState(() {
      _taggedRecipeId = picked.id;
      _taggedRecipeTitle = picked.title;
      _taggedRecipeThumb = picked.thumbnailUrl;
    });
  }

  void _clearTaggedRecipe() {
    setState(() {
      _taggedRecipeId = null;
      _taggedRecipeTitle = null;
      _taggedRecipeThumb = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);
    final textPrimary = AppColors.getTextPrimary(brightness);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 52,
        leading: IconButton(
          icon: Icon(Icons.close_rounded, color: textPrimary, size: 26),
          onPressed: () => Navigator.of(context).maybePop(),
          padding: EdgeInsets.zero,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: _DoneButton(
              label: _isEdit ? '수정' : '완료',
              enabled: _canSubmit,
              loading: _submitting,
              onPressed: _submit,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                // Tapping anywhere in the empty canvas drops focus into the
                // body field, just like 당근 — keeps the writing flow fluid.
                behavior: HitTestBehavior.translucent,
                onTap: () => _bodyFocus.requestFocus(),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ContextHeader(
                        category: _category,
                        onTapCategory: _pickCategory,
                      ),
                      const SizedBox(height: 14),
                      _RecipeTagBar(
                        title: _taggedRecipeTitle,
                        thumbnailUrl: _taggedRecipeThumb,
                        onPick: _pickRecipe,
                        onClear: _taggedRecipeId == null
                            ? null
                            : _clearTaggedRecipe,
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _titleController,
                        maxLength: 80,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _bodyFocus.requestFocus(),
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: textPrimary,
                          height: 1.35,
                          letterSpacing: -0.35,
                        ),
                        decoration: const InputDecoration(
                          hintText: '제목을 입력해주세요.',
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFD1D5DB),
                            letterSpacing: -0.35,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          counterText: '',
                          isCollapsed: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _bodyController,
                        focusNode: _bodyFocus,
                        maxLines: null,
                        minLines: 6,
                        maxLength: 3000,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          height: 1.6,
                          color: textPrimary,
                          letterSpacing: -0.25,
                        ),
                        decoration: const InputDecoration(
                          hintText: '가벼운 고민이든, 구체적인 질문이든 편하게 남겨보세요.',
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            height: 1.6,
                            color: Color(0xFFD1D5DB),
                            letterSpacing: -0.25,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          counterText: '',
                          isCollapsed: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const _TipCard(),
          ],
        ),
      ),
    );
  }
}

class _ContextHeader extends StatelessWidget {
  const _ContextHeader({required this.category, required this.onTapCategory});

  final BoardCategory category;
  final VoidCallback onTapCategory;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Neutral grey container + monochrome glyph: doesn't fight with the
        // orange "완료" CTA in the app bar, and the squarcle proportions
        // (44 box / 22 glyph) match the visual weight of the name+chip stack
        // on its right so the row reads as balanced rather than top-heavy.
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.edit_note_rounded,
            color: Color(0xFF6B7280),
            size: 24,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '요리GO 속닥속닥',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                  letterSpacing: -0.3,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: onTapCategory,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        category.label,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF4B5563),
                          letterSpacing: -0.2,
                          height: 1.2,
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: Color(0xFF9CA3AF),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF5EC),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'TIP',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFFFF7300),
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '속닥속닥에서는 이런 이야기를 나눠보세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TipBullet(text: '간 맞추기, 실패담, 오늘 뭐 먹지처럼 가벼운 고민을 올려요.'),
                SizedBox(height: 6),
                _TipBullet(text: '구체적인 조언이 필요하거나, 나만의 팁을 나눠도 좋아요.'),
                SizedBox(height: 6),
                _TipBullet(text: '운영정책에 어긋나는 글은 비공개 처리될 수 있어요.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeTagBar extends StatelessWidget {
  const _RecipeTagBar({
    required this.title,
    required this.thumbnailUrl,
    required this.onPick,
    this.onClear,
  });

  final String? title;
  final String? thumbnailUrl;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final tagged = title != null && title!.isNotEmpty;
    return GestureDetector(
        onTap: onPick,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF0F1F3)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 36,
                  height: 45,
                  child: tagged && (thumbnailUrl ?? '').isNotEmpty
                      ? AppNetworkImage(
                          imageUrl: thumbnailUrl!,
                          fit: BoxFit.cover,
                          width: 36,
                          height: 45,
                        )
                      : const ColoredBox(
                          color: Color(0xFFEEF0F3),
                          child: Icon(
                            Icons.restaurant_rounded,
                            size: 20,
                            color: Color(0xFF9CA3AF),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tagged ? title! : '레시피 카드 태그하기',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: tagged
                        ? const Color(0xFF111827)
                        : const Color(0xFF6B7280),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (onClear != null)
                IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: const Color(0xFF9CA3AF),
                  visualDensity: VisualDensity.compact,
                )
              else
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF9CA3AF),
                ),
            ],
          ),
        ),
    );
  }
}

class _TipBullet extends StatelessWidget {
  const _TipBullet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 7, right: 8),
          child: SizedBox(
            width: 3,
            height: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF9CA3AF),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              height: 1.5,
              color: Color(0xFF6B7280),
              letterSpacing: -0.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _DoneButton extends StatelessWidget {
  const _DoneButton({
    required this.label,
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFFFF7300) : const Color(0xFFD1D5DB);
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: color,
                  letterSpacing: -0.3,
                ),
              ),
      ),
    );
  }
}
