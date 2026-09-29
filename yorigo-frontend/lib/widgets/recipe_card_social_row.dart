import 'package:flutter/material.dart';

import '../utils/recipe_social_counts.dart';

/// Compact view + bookmark counts for home/list recipe cards.
class RecipeCardSocialRow extends StatelessWidget {
  const RecipeCardSocialRow({
    super.key,
    required this.recipe,
    required this.color,
  });

  final Map<String, dynamic> recipe;
  final Color color;

  static int? viewCountOf(Map<String, dynamic> recipe) {
    return RecipeSocialCounts.viewCountOf(recipe);
  }

  static int saveCountOf(Map<String, dynamic> recipe) {
    return RecipeSocialCounts.saveCountOf(recipe);
  }

  static String formatCount(int n) {
    if (n >= 100000000) {
      final v = n / 100000000;
      return '${v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}억';
    }
    if (n >= 10000) {
      final v = n / 10000;
      return '${v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}만';
    }
    final digits = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final views = viewCountOf(recipe);
    final saves = saveCountOf(recipe);
    const rowHeight = 14.0;
    const iconSize = 12.0;
    final style = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: color,
      height: 1,
      letterSpacing: -0.2,
      leadingDistribution: TextLeadingDistribution.even,
    );
    const strut = StrutStyle(
      fontFamily: 'Pretendard',
      fontSize: 10.5,
      height: 1,
      leading: 0,
      forceStrutHeight: true,
    );

    Widget slot({required Widget child}) {
      return SizedBox(
        height: rowHeight,
        child: Center(child: child),
      );
    }

    Widget item(IconData icon, String value, {double iconDy = 0}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          slot(
            child: Transform.translate(
              offset: Offset(0, iconDy),
              child: Icon(icon, size: iconSize, color: color),
            ),
          ),
          const SizedBox(width: 3),
          slot(
            child: Text(
              value,
              style: style,
              strutStyle: strut,
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          item(
            Icons.play_circle_outline_rounded,
            views == null ? '—' : formatCount(views),
            iconDy: -0.5,
          ),
          const SizedBox(width: 8),
          item(Icons.bookmark_border_rounded, formatCount(saves)),
        ],
      ),
    );
  }
}
