import 'package:flutter/material.dart';

/// Figma 514:330 — pill field: white fill, #FF7518 border,
/// 13.5px medium text; placeholder rgba(17,17,17,0.5).
class RecipeSearchTextField extends StatelessWidget {
  const RecipeSearchTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '레시피 검색...',
    this.hintStyle,
    this.textInputAction = TextInputAction.search,
    this.readOnly = false,
    this.onTap,
    this.onSubmitted,
    this.centerOverlay,
    this.leading,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  /// Defaults to Figma placeholder (50% #111).
  final TextStyle? hintStyle;
  final TextInputAction textInputAction;
  final bool readOnly;
  final VoidCallback? onTap;
  final ValueChanged<String>? onSubmitted;
  /// When non-null, drawn at the start of the input lane (right of logo; hint hidden).
  final Widget? centerOverlay;
  /// Replaces the GO logo when non-null (e.g. back control while browsing).
  final Widget? leading;

  static const Color _borderOrange = Color(0xFFFF7518);
  static const Color _textPrimary = Color(0xFF111111);
  /// Default GO logo in pill (+7% vs 29.85). Same width used to inset the text field.
  static const double goLogoSlotSize = 31.94;
  /// Trailing search magnifier size; leading back uses [leadingBackIconSize].
  static const double searchIconSize = 19.8;
  /// Back icon in leading slot: same size as search magnifier.
  static const double leadingBackIconSize = searchIconSize;
  static const double barHeight = 44;

  static final TextStyle _defaultHintStyle = TextStyle(
    fontFamily: 'Pretendard',
    color: const Color(0xFF111111).withValues(alpha: 0.5),
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.0,
  );

  @override
  Widget build(BuildContext context) {
    final showOverlay = centerOverlay != null;

    return Container(
      width: double.infinity,
      height: barHeight,
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(width: 1, color: _borderOrange),
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.center,
              child: leading ??
                  Icon(
                    Icons.search_rounded,
                    size: searchIconSize,
                    color: Color(0x99FF7518),
                  ),
            ),
          ),
          Positioned(
            left: 12 + searchIconSize + 8,
            right: 14,
            top: 0,
            bottom: 0,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final hideHint =
                          showOverlay || value.text.isNotEmpty;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          readOnly: readOnly,
                          onTap: onTap,
                          textAlignVertical: TextAlignVertical.center,
                          decoration: InputDecoration(
                            hintText: hideHint ? '' : hintText,
                            hintStyle: hintStyle ?? _defaultHintStyle,
                            border: InputBorder.none,
                            isCollapsed: true,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            color: _textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.15,
                          ),
                          textInputAction: textInputAction,
                          onSubmitted: onSubmitted,
                        ),
                      );
                    },
                  ),
                ),
                if (centerOverlay != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: centerOverlay,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Back control when [RecipeSearchTextField.leading] replaces the GO logo (e.g. browse-all mode).
/// The icon is 20% larger than [RecipeSearchTextField.searchIconSize]; the pill height and
/// text inset are unchanged. Tap target is wider than the icon (extra width on the left only,
/// kept within layout so hits are not clipped by a tight [Stack]).
class RecipeSearchLeadingBackButton extends StatelessWidget {
  const RecipeSearchLeadingBackButton({
    super.key,
    required this.onPressed,
    required this.color,
  });

  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const double tapWidth = 40;
    final double iconSize = RecipeSearchTextField.leadingBackIconSize;
    final double extraLeft = (tapWidth - iconSize) / 2;
    return Transform.translate(
      offset: Offset(-extraLeft, 0),
      child: SizedBox(
        width: tapWidth,
        height: RecipeSearchTextField.barHeight,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(22),
            child: Center(
              child: Icon(
                Icons.arrow_back_rounded,
                size: iconSize,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
