import 'package:flutter/material.dart';

/// Korean YORIGO wordmark logo for app bars and headers.
class YorigoHeaderLogo extends StatelessWidget {
  const YorigoHeaderLogo({
    super.key,
    this.height = 24,
    this.maxWidth,
  });

  final double height;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    const double headerScale = 0.92; // 8% smaller across all header usages
    final scaledHeight = height * headerScale;
    final scaledMaxWidth = maxWidth == null ? null : maxWidth! * headerScale;

    final w = Image.asset(
      'assets/yorigo_korean_logo.png',
      height: scaledHeight,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      errorBuilder: (_, __, ___) => Text(
        '요리고',
        style: TextStyle(
          fontSize: scaledHeight * 0.75,
          fontWeight: FontWeight.w800,
          color: const Color(0xFFFF6900),
        ),
      ),
    );
    if (scaledMaxWidth != null) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: scaledMaxWidth),
        child: w,
      );
    }
    return w;
  }
}
